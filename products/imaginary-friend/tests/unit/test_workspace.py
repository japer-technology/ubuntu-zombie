from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from friend.errors import ConflictError, ValidationError
from friend.workspace import Workspace, WorkspaceRoot, validate_nominated_root


class WorkspaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o2770)
        details = validate_nominated_root(self.root)
        self.workspace = Workspace(
            WorkspaceRoot(
                workspace_id="workspace",
                path=self.root,
                device=details.st_dev,
                inode=details.st_ino,
            )
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_atomic_create_read_and_optimistic_replace(self) -> None:
        created = self.workspace.write("note.txt", "one")
        self.assertTrue(created["created"])
        read = self.workspace.read("note.txt")
        self.assertEqual(read["content"], "one")
        with self.assertRaises(ConflictError):
            self.workspace.write("note.txt", "two")
        replaced = self.workspace.write(
            "note.txt", "two", expected_sha256=read["sha256"]
        )
        self.assertFalse(replaced["created"])
        self.assertEqual(self.workspace.read("note.txt")["content"], "two")

    def test_traversal_absolute_and_symlink_reads_are_rejected(self) -> None:
        outside = self.root.parent / f"{self.root.name}-outside"
        outside.write_text("outside", encoding="utf-8")
        try:
            (self.root / "link").symlink_to(outside)
            for path in ("../outside", "/etc/passwd", "a/../b", "link"):
                with self.assertRaises(ValidationError, msg=path):
                    self.workspace.read(path)
        finally:
            outside.unlink(missing_ok=True)

    def test_hard_links_and_special_files_are_rejected(self) -> None:
        original = self.root / "original"
        original.write_text("content", encoding="utf-8")
        os.link(original, self.root / "hardlink")
        with self.assertRaises(ValidationError):
            self.workspace.read("hardlink")

    def test_root_replacement_is_detected(self) -> None:
        original = self.root.with_name(f"{self.root.name}-old")
        self.root.rename(original)
        self.root.mkdir()
        try:
            with self.assertRaises(ValidationError):
                self.workspace.list()
        finally:
            self.root.rmdir()
            original.rename(self.root)

    def test_move_delete_and_empty_directory_rules(self) -> None:
        self.workspace.mkdir("folder")
        self.workspace.write("folder/a.txt", "a")
        self.workspace.move("folder/a.txt", "folder/b.txt")
        self.assertEqual(self.workspace.read("folder/b.txt")["content"], "a")
        with self.assertRaises(ConflictError):
            self.workspace.delete("folder")
        self.workspace.delete("folder/b.txt")
        self.workspace.delete("folder")
        self.assertEqual(self.workspace.list()["entries"], [])

    def test_mutations_require_shared_group_inheritance(self) -> None:
        unsafe = self.root / "unsafe"
        unsafe.mkdir(mode=0o0770)
        unsafe.chmod(0o0770)
        with self.assertRaises(ValidationError):
            self.workspace.write("unsafe/file.txt", "content")
        with self.assertRaises(ValidationError):
            self.workspace.mkdir("unsafe/folder")

        unsafe.chmod(0o2770)
        self.workspace.write("unsafe/file.txt", "content")
        self.workspace.mkdir("unsafe/folder")
        self.assertEqual((unsafe / "file.txt").stat().st_gid, self.root.stat().st_gid)
        self.assertEqual((unsafe / "folder").stat().st_gid, self.root.stat().st_gid)


if __name__ == "__main__":
    unittest.main()
