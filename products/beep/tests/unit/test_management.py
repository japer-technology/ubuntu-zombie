from __future__ import annotations

import os
import stat
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

from beep import management


PRODUCT_ROOT = Path(__file__).resolve().parents[2]


def temporary_paths(root: Path) -> management.Paths:
    return management.Paths(
        install_root=root / "opt" / "beep",
        configuration_root=root / "etc" / "beep",
        state_root=root / "var" / "lib" / "beep",
        log_root=root / "var" / "log" / "beep",
        chat_unit=root / "systemd" / "beep-chat.service",
        health_unit=root / "systemd" / "beep-health.service",
        health_timer=root / "systemd" / "beep-health.timer",
        logrotate=root / "logrotate" / "beep",
        sudoers=root / "sudoers" / "90-beep",
        entrypoint=root / "bin" / "beep-manage",
        lock=root / "run" / "beep.lock",
        rollback_root=root / "var" / "lib" / "beep" / "recovery",
    )


class ManagementTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manager = management.Manager(PRODUCT_ROOT)
        self.manager.paths = temporary_paths(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_descriptor_exposes_terminal_kill_operation(self) -> None:
        self.assertIn("kill", management.OPERATIONS)
        self.assertEqual(self.manager.descriptor["operations"], list(management.OPERATIONS))

    def test_atomic_write_rejects_non_regular_destination(self) -> None:
        destination = self.root / "destination"
        destination.mkdir()
        with self.assertRaises(management.ManagementError) as raised:
            management.atomic_write(destination, b"value", mode=0o600)
        self.assertEqual(raised.exception.code, "UNSAFE_PATH")

    def test_collision_preflight_detects_independent_group(self) -> None:
        with (
            mock.patch.object(self.manager, "_load_retained", return_value=None),
            mock.patch.object(management.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(
                management.grp,
                "getgrnam",
                return_value=types.SimpleNamespace(gr_gid=123),
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._collision_preflight(None)
        self.assertEqual(raised.exception.code, "OWNERSHIP_COLLISION")
        self.assertIn("group:beep", raised.exception.message)

    def test_directory_convergence_rejects_regular_file(self) -> None:
        self.manager.paths.install_root.parent.mkdir(parents=True)
        self.manager.paths.install_root.write_text("collision", encoding="utf-8")
        with mock.patch.object(management.os, "chown"):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._ensure_directories(1000, 1000, [])
        self.assertEqual(raised.exception.code, "UNSAFE_PATH")

    def test_runtime_deployment_preserves_executable_modes(self) -> None:
        node = self.manager.paths.node_root / "bin" / "node"
        node.parent.mkdir(parents=True)
        node.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        os.chmod(node, 0o755)
        self.manager.paths.runtime.mkdir(parents=True)
        configuration = management.Configuration(
            agent_user="beep",
            chat_port=58989,
            provider=None,
            model=None,
            model_base_url=None,
            ttl_days=7,
        )
        with (
            mock.patch.object(self.manager, "_deploy_family_schemas"),
            mock.patch.object(self.manager, "_deploy_product_source"),
            mock.patch.object(self.manager, "_deploy_pi_models"),
            mock.patch.object(management.os, "chown"),
        ):
            self.manager._deploy_runtime(configuration, 1000, 1000, [])
        self.assertEqual(stat.S_IMODE(node.stat().st_mode), 0o755)
        self.assertEqual(
            stat.S_IMODE(
                (self.manager.paths.install_root / "bin" / "beep-chat").stat().st_mode
            ),
            0o755,
        )
        self.assertEqual(
            stat.S_IMODE(
                (self.manager.paths.install_root / "agent" / "server.py").stat().st_mode
            ),
            0o644,
        )


if __name__ == "__main__":
    unittest.main()
