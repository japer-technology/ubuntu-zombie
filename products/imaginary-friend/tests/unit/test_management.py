from __future__ import annotations

import argparse
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

from friend.auth import hash_password
from friend.database import Database
from friend.management import Invocation, ManagementError, Manager, Paths

SOURCE_ROOT = Path(__file__).resolve().parents[2]


class FakeDatabase:
    def set_suspended(self, _suspended: bool) -> None:
        return


class ManagementUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.paths = Paths(
            install_root=root / "opt" / "imaginary-friend",
            configuration_root=root / "etc" / "imaginary-friend",
            state_root=root / "var" / "lib" / "imaginary-friend",
            log_root=root / "var" / "log" / "imaginary-friend",
            workspace_parent=root / "srv" / "imaginary-friend",
            unit=root / "etc" / "systemd" / "imaginary-friend-chat.service",
            logrotate=root / "etc" / "logrotate.d" / "imaginary-friend",
            entrypoint=root / "usr" / "local" / "sbin" / "friend-manage",
            diagnostics=root / "usr" / "local" / "bin" / "friend-diagnostics",
            lock=root / "run" / "lock" / "imaginary-friend.lock",
            rollback_root=root / "opt" / ".imaginary-friend-rollback",
        )
        self.manager = Manager(SOURCE_ROOT)
        self.manager.paths = self.paths
        self.instance_id = str(uuid.uuid4())
        self.marker = {
            "schema_version": 1,
            "product_id": "imaginary-friend",
            "instance_id": self.instance_id,
            "version": self.manager.version,
            "source_revision": "source-tree-sha256:" + "0" * 64,
            "installed_at": "2026-08-08T00:00:00Z",
            "install_root": str(self.paths.install_root),
            "lifecycle_entrypoint": str(self.paths.entrypoint),
            "artifact_sha256": None,
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invocation(self, operation: str = "install") -> Invocation:
        return Invocation(
            operation,
            str(uuid.uuid4()),
            "operator",
            {
                "owner_user": "owner",
                "model_base_url": "http://127.0.0.1:8080/v1",
                "model": "fixture-friend",
                "history_retention_days": 30,
                "audit_retention_days": 90,
            },
            None,
            None,
            False,
            True,
            True,
            True,
            None,
            None,
            None,
            [Path("/srv/imaginary-friend/workspace")],
        )

    def test_clean_install_boundary_check_accepts_valid_transaction(self) -> None:
        missing = ManagementError(
            66, "INSTALLATION_MISSING", "Imaginary Friend is not installed."
        )
        with mock.patch.object(self.manager, "load_marker", side_effect=missing):
            with mock.patch.object(
                self.manager, "_transaction_instance", return_value=self.instance_id
            ):
                checks = self.manager.verify_checks(
                    probe_runtime=False, allow_transaction=True
                )
        self.assertEqual(checks[0]["id"], "installation_transaction")
        self.assertEqual(checks[0]["status"], "pass")

    def test_clean_install_writes_marker_only_after_boundary_checks(self) -> None:
        events: list[str] = []

        def verify(**options: bool) -> list[dict[str, str]]:
            self.assertTrue(options["allow_transaction"])
            self.assertNotIn("marker", events)
            events.append("verify")
            return [self.manager.check("boundaries", True, "Boundaries passed.")]

        def write_marker(*_args: object, **_kwargs: object) -> None:
            events.append("marker")

        names = {
            "_platform_preflight": mock.DEFAULT,
            "_validate_owner": mock.DEFAULT,
            "_collision_preflight": mock.DEFAULT,
            "_workspace_preflight": mock.DEFAULT,
            "_probe_model": mock.DEFAULT,
            "_ensure_transaction": mock.DEFAULT,
            "_ensure_accounts": mock.DEFAULT,
            "_ensure_paths": mock.DEFAULT,
            "_stage_runtime": mock.DEFAULT,
            "_deploy_configuration": mock.DEFAULT,
            "_initialize_database": mock.DEFAULT,
            "_deploy_unit": mock.DEFAULT,
            "_validate_runtime_as_friend": mock.DEFAULT,
            "_start_service": mock.DEFAULT,
            "_service_health": mock.DEFAULT,
            "verify_checks": mock.DEFAULT,
            "_write_marker": mock.DEFAULT,
            "_restore_failed_switch": mock.DEFAULT,
        }
        with mock.patch.multiple(self.manager, **names) as patched, mock.patch.object(
            self.manager, "load_marker", side_effect=[None, self.marker]
        ), mock.patch("friend.management.grp.getgrnam") as group:
            patched["_ensure_transaction"].return_value = self.instance_id
            patched["_ensure_accounts"].return_value = (100, 200)
            patched["_stage_runtime"].return_value = None
            patched["_initialize_database"].return_value = FakeDatabase()
            patched["_service_health"].return_value = True
            patched["verify_checks"].side_effect = verify
            patched["_write_marker"].side_effect = write_marker
            group.return_value.gr_gid = 100
            self.manager._execute_install(self.invocation())
        self.assertEqual(events, ["verify", "marker"])
        patched["_restore_failed_switch"].assert_not_called()

    def test_deployment_failure_requests_runtime_restore(self) -> None:
        names = {
            "_platform_preflight": mock.DEFAULT,
            "_validate_owner": mock.DEFAULT,
            "_collision_preflight": mock.DEFAULT,
            "_workspace_preflight": mock.DEFAULT,
            "_probe_model": mock.DEFAULT,
            "_snapshot_recovery": mock.DEFAULT,
            "_ensure_transaction": mock.DEFAULT,
            "_ensure_accounts": mock.DEFAULT,
            "_ensure_paths": mock.DEFAULT,
            "_stage_runtime": mock.DEFAULT,
            "_deploy_configuration": mock.DEFAULT,
            "_restore_failed_switch": mock.DEFAULT,
        }
        with mock.patch.multiple(self.manager, **names) as patched, mock.patch.object(
            self.manager, "load_marker", return_value=self.marker
        ), mock.patch("friend.management.grp.getgrnam") as group:
            patched["_ensure_transaction"].return_value = self.instance_id
            patched["_ensure_accounts"].return_value = (100, 200)
            patched["_stage_runtime"].return_value = self.manager.version
            patched["_deploy_configuration"].side_effect = OSError(
                "simulated deployment failure"
            )
            group.return_value.gr_gid = 100
            with self.assertRaises(OSError):
                self.manager._execute_install(self.invocation())
        patched["_restore_failed_switch"].assert_called_once_with(
            runtime_switched=True
        )

    def test_resume_prepares_installed_model_configuration(self) -> None:
        self.paths.state_root.mkdir(parents=True)
        self.paths.configuration_root.mkdir(parents=True)
        database = Database(self.paths.database)
        database.initialize(
            password_hash=hash_password("initial owner password"),
            model_base_url="http://127.0.0.1:8080/v1",
            model="fixture-friend",
            history_retention_days=30,
            audit_retention_days=90,
        )
        (self.paths.configuration_root / "config.json").write_text(
            '{"owner_user":"owner"}', encoding="utf-8"
        )
        arguments = argparse.Namespace(
            operation="resume",
            request_file=None,
            correlation_id=None,
            dry_run=True,
            json=True,
            non_interactive=False,
            yes=False,
            plan_digest=None,
        )
        with mock.patch.dict(
            os.environ, {"FRIEND_NONINTERACTIVE": "1"}, clear=True
        ):
            invocation = self.manager.invocation(arguments)
        self.assertEqual(
            invocation.inputs["model_base_url"], "http://127.0.0.1:8080/v1"
        )
        self.assertEqual(invocation.inputs["model"], "fixture-friend")

    def test_unattended_reinstall_uses_existing_credentials_and_settings(self) -> None:
        self.paths.state_root.mkdir(parents=True)
        self.paths.configuration_root.mkdir(parents=True)
        Database(self.paths.database).initialize(
            password_hash=hash_password("initial owner password"),
            model_base_url="http://127.0.0.1:8080/v1",
            model="fixture-friend",
            history_retention_days=30,
            audit_retention_days=90,
        )
        (self.paths.configuration_root / "config.json").write_text(
            '{"owner_user":"owner"}', encoding="utf-8"
        )
        arguments = argparse.Namespace(
            operation="install",
            request_file=None,
            correlation_id=None,
            dry_run=True,
            json=True,
            non_interactive=False,
            yes=False,
            plan_digest=None,
        )
        with mock.patch.dict(
            os.environ, {"FRIEND_NONINTERACTIVE": "1"}, clear=True
        ):
            invocation = self.manager.invocation(arguments)
        self.assertIsNone(invocation.password)
        self.assertEqual(invocation.inputs["owner_user"], "owner")
        self.assertEqual(invocation.inputs["model"], "fixture-friend")

    def test_repair_preserves_restricted_workspace_without_new_file(self) -> None:
        self.paths.state_root.mkdir(parents=True)
        workspace = Path(self.temporary.name) / "workspace"
        workspace.mkdir()
        details = workspace.stat()
        database = Database(self.paths.database)
        database.initialize(
            password_hash=hash_password("initial owner password"),
            model_base_url="http://127.0.0.1:8080/v1",
            model="fixture-friend",
            history_retention_days=30,
            audit_retention_days=90,
        )
        workspace_id = database.register_workspace(
            canonical_root=str(workspace),
            root_device=details.st_dev,
            root_inode=details.st_ino,
            enabled=False,
        )
        invocation = self.invocation("repair")
        self.manager._initialize_database(
            invocation,
            friend_uid=os.getuid(),
            friend_gid=os.getgid(),
            workspaces=[workspace],
        )
        self.assertFalse(
            Database(self.paths.database).workspace(
                workspace_id, require_enabled=False
            )["enabled"]
        )

    def test_dry_run_preflight_reports_missing_installation(self) -> None:
        invocation = self.invocation("suspend")
        invocation.dry_run = True
        checks = self.manager.preflight_checks(invocation, network=False)
        self.assertEqual(checks[0]["id"], "ownership_marker")
        self.assertEqual(checks[0]["status"], "fail")

    def test_backup_dry_run_requires_existing_destination(self) -> None:
        missing = Path(self.temporary.name) / "missing-backup"
        with self.assertRaises(ManagementError) as raised:
            self.manager._validate_backup_destination(missing, dry_run=True)
        self.assertEqual(raised.exception.exit_code, 66)


if __name__ == "__main__":
    unittest.main()
