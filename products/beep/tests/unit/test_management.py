from __future__ import annotations

import hashlib
import io
import os
import stat
import subprocess
import tarfile
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
        account_home=root / "home" / "beep",
        configuration_root=root / "etc" / "beep",
        state_root=root / "var" / "lib" / "beep",
        log_root=root / "var" / "log" / "beep",
        chat_unit=root / "systemd" / "beep-chat.service",
        health_unit=root / "systemd" / "beep-health.service",
        health_timer=root / "systemd" / "beep-health.timer",
        logrotate=root / "logrotate" / "beep",
        sudoers=root / "sudoers" / "90-beep",
        entrypoint=root / "bin" / "beep-manage",
        command_root=root / "bin" / "commands",
        lock=root / "run" / "beep.lock",
        rollback_root=root / "var" / "lib" / "beep" / "recovery",
    )


def default_configuration() -> management.Configuration:
    return management.Configuration(
        agent_user="beep",
        chat_port=58989,
        provider=None,
        model=None,
        model_base_url=None,
        ttl_days=7,
    )


def pending_state(
    manager: management.Manager,
    configuration: management.Configuration | None = None,
) -> dict[str, object]:
    selected = configuration or default_configuration()
    resources = {
        str(path): {
            "mode": mode,
            "sha256": [hashlib.sha256(content).hexdigest()],
        }
        for path, (content, mode) in manager._host_resource_specs(selected).items()
    }
    return {
        "schema_version": 1,
        "product_id": "beep",
        "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
        "started_at": "2026-08-11T00:00:00Z",
        "version": manager.version,
        "source_revision": manager._source_revision(),
        "configuration": selected.object(),
        "adopted_legacy": False,
        "host_resources": resources,
    }


def purge_state(
    manager: management.Manager,
    *,
    identity: dict[str, int | None] | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "product_id": "beep",
        "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
        "started_at": "2026-08-11T00:00:00Z",
        "version": manager.version,
        "identity": identity
        or {"user_uid": None, "user_gid": None, "group_gid": None},
    }


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

    def test_plan_digest_binds_source_revision(self) -> None:
        invocation = management.Invocation(
            operation="install",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        with mock.patch.object(
            self.manager,
            "_source_revision",
            side_effect=["source:" + "1" * 64, "source:" + "2" * 64],
        ):
            before = self.manager.plan_digest(
                invocation,
                [],
                default_configuration(),
            )
            after = self.manager.plan_digest(
                invocation,
                [],
                default_configuration(),
            )
        self.assertNotEqual(before, after)

    def test_source_revision_is_not_disabled_by_a_dist_ancestor(self) -> None:
        source = self.root / "dist" / "product"
        source.mkdir(parents=True)
        payload = source / "payload.txt"
        payload.write_text("before\n", encoding="utf-8")
        self.manager.source_root = source

        before = self.manager._source_revision()
        payload.write_text("after\n", encoding="utf-8")
        after = self.manager._source_revision()

        self.assertNotEqual(before, after)

    def test_trusted_source_snapshot_rejects_revision_drift(self) -> None:
        original = self.manager.source_root
        with self.assertRaises(management.ManagementError) as raised:
            with self.manager._trusted_source_snapshot("source:" + "0" * 64):
                self.fail("a mismatched source snapshot must not be used")
        self.assertEqual(raised.exception.code, "PLAN_CHANGED")
        self.assertEqual(self.manager.source_root, original)

    def test_interactive_install_collects_validated_configuration(self) -> None:
        arguments = management.parser().parse_args(["install"])
        inputs: dict[str, object] = {}
        answers = [
            "80",
            "",
            "unknown",
            "openai",
            "",
            "",
            "0",
            "",
        ]
        with (
            mock.patch.object(
                management.sys.stdin,
                "isatty",
                return_value=True,
            ),
            mock.patch.object(
                self.manager,
                "_prompt",
                side_effect=answers,
            ),
        ):
            self.manager._prepare_interactive_install(
                arguments,
                inputs,
                request_supplied=False,
                non_interactive=False,
            )
        self.assertEqual(
            inputs,
            {
                "chat_port": 58989,
                "provider": "openai",
                "model": None,
                "model_base_url": None,
                "ttl_days": 7,
            },
        )

    def test_approved_install_skips_setup_questions(self) -> None:
        arguments = management.parser().parse_args(["install", "--yes"])
        with mock.patch.object(self.manager, "_prompt") as prompt:
            self.manager._prepare_interactive_install(
                arguments,
                {},
                request_supplied=False,
                non_interactive=False,
            )
        prompt.assert_not_called()

    def test_interactive_approval_displays_configuration_and_plan(self) -> None:
        invocation = management.Invocation(
            operation="install",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={
                "chat_port": 59000,
                "provider": None,
                "ttl_days": 14,
            },
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=False,
            non_interactive=False,
            assume_yes=False,
            supplied_plan_digest=None,
        )
        output = io.StringIO()
        with (
            mock.patch.object(
                management.sys.stdin,
                "isatty",
                return_value=True,
            ),
            mock.patch.object(self.manager, "_prompt", return_value="no"),
            mock.patch("sys.stdout", output),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager.run(invocation)
        self.assertEqual(raised.exception.code, "CONFIRMATION_REQUIRED")
        self.assertIn("Chat URL:", output.getvalue())
        self.assertIn("http://127.0.0.1:59000/", output.getvalue())
        self.assertIn("Time to live:", output.getvalue())
        self.assertIn("14 days", output.getvalue())
        self.assertIn("Converge Beep-only credentials", output.getvalue())
        self.assertFalse(self.manager.paths.lock.exists())

    def test_interactive_provider_credential_retries_invalid_input(self) -> None:
        with (
            mock.patch.object(
                management.sys.stdin,
                "isatty",
                return_value=True,
            ),
            mock.patch.object(
                management.getpass,
                "getpass",
                side_effect=["", "provider-secret"],
            ) as prompt,
        ):
            value = self.manager._interactive_provider_credential("openai")
        self.assertEqual(value, "provider-secret")
        self.assertEqual(prompt.call_count, 2)

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

    def test_collision_preflight_accepts_proven_pending_install(self) -> None:
        self.manager.paths.install_root.mkdir(parents=True)
        os.chmod(self.manager.paths.install_root, 0o755)
        pending = pending_state(self.manager)
        with (
            mock.patch.object(self.manager, "_load_pending_install", return_value=pending),
            mock.patch.object(self.manager, "_load_retained", return_value=None),
            mock.patch.object(
                management.pwd,
                "getpwnam",
                return_value=types.SimpleNamespace(
                    pw_uid=os.geteuid(),
                    pw_gid=1000,
                    pw_dir=str(self.manager.paths.account_home),
                    pw_shell="/bin/bash",
                ),
            ),
            mock.patch.object(
                management.grp,
                "getgrnam",
                return_value=types.SimpleNamespace(gr_gid=1000),
            ),
        ):
            recovered_legacy = self.manager._collision_preflight(None)
        self.assertFalse(recovered_legacy)

    def test_pending_install_rejects_unrecorded_host_resource(self) -> None:
        pending = pending_state(self.manager)
        self.manager.paths.command_root.mkdir(parents=True)
        command = self.manager.paths.command_root / management.HOST_COMMANDS[0]
        command.write_bytes(b"unrelated command\n")
        os.chmod(command, 0o755)
        with (
            mock.patch.object(self.manager, "_load_retained", return_value=None),
            mock.patch.object(management.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(management.grp, "getgrnam", side_effect=KeyError),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._collision_preflight(
                    None,
                    pending=pending,
                    configuration=default_configuration(),
                )
        self.assertEqual(raised.exception.code, "OWNERSHIP_COLLISION")
        self.assertEqual(command.read_bytes(), b"unrelated command\n")

    def test_collision_preflight_rejects_every_host_command_collision(self) -> None:
        self.manager.paths.command_root.mkdir(parents=True)
        for name in management.HOST_COMMANDS:
            path = self.manager.paths.command_root / name
            path.write_bytes(b"unrelated command\n")
            with (
                mock.patch.object(self.manager, "_load_pending_install", return_value=None),
                mock.patch.object(self.manager, "_load_retained", return_value=None),
                mock.patch.object(self.manager, "_legacy_partial_install", return_value=False),
                mock.patch.object(management.pwd, "getpwnam", side_effect=KeyError),
                mock.patch.object(management.grp, "getgrnam", side_effect=KeyError),
            ):
                with self.assertRaises(management.ManagementError) as raised:
                    self.manager._collision_preflight(None)
            self.assertEqual(raised.exception.code, "OWNERSHIP_COLLISION")
            self.assertIn(str(path), raised.exception.message)
            self.assertEqual(path.read_bytes(), b"unrelated command\n")
            path.unlink()

    def test_collision_preflight_rejects_dangling_host_command_link(self) -> None:
        self.manager.paths.command_root.mkdir(parents=True)
        path = self.manager.paths.command_root / management.HOST_COMMANDS[0]
        try:
            path.symlink_to(self.root / "missing-command")
        except OSError as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        with (
            mock.patch.object(self.manager, "_load_pending_install", return_value=None),
            mock.patch.object(self.manager, "_load_retained", return_value=None),
            mock.patch.object(self.manager, "_legacy_partial_install", return_value=False),
            mock.patch.object(management.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(management.grp, "getgrnam", side_effect=KeyError),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._collision_preflight(None)
        self.assertEqual(raised.exception.code, "OWNERSHIP_COLLISION")
        self.assertTrue(path.is_symlink())

    def test_collision_preflight_rejects_unowned_account_home(self) -> None:
        self.manager.paths.account_home.mkdir(parents=True)
        sentinel = self.manager.paths.account_home / "keep"
        sentinel.write_text("unrelated\n", encoding="utf-8")
        with (
            mock.patch.object(self.manager, "_load_pending_install", return_value=None),
            mock.patch.object(self.manager, "_load_retained", return_value=None),
            mock.patch.object(self.manager, "_legacy_partial_install", return_value=False),
            mock.patch.object(management.pwd, "getpwnam", side_effect=KeyError),
            mock.patch.object(management.grp, "getgrnam", side_effect=KeyError),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._collision_preflight(None)
        self.assertEqual(raised.exception.code, "OWNERSHIP_COLLISION")
        self.assertIn(str(self.manager.paths.account_home), raised.exception.message)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unrelated\n")

    def test_lifecycle_lock_path_remains_bound_while_busy(self) -> None:
        first = self.manager._lock()
        first.__enter__()
        try:
            for _ in range(2):
                with self.assertRaises(management.ManagementError) as raised:
                    with self.manager._lock():
                        self.fail("a second lifecycle lock was acquired")
                self.assertEqual(raised.exception.code, "TARGET_BUSY")
                self.assertTrue(self.manager.paths.lock.is_file())
        finally:
            first.__exit__(None, None, None)
        with self.manager._lock():
            self.assertTrue(self.manager.paths.lock.is_file())
        self.assertTrue(self.manager.paths.lock.is_file())

    def test_markerless_failure_stops_services_and_keeps_retry_state(self) -> None:
        invocation = management.Invocation(
            operation="install",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        configuration = default_configuration()
        failure = management.ManagementError(
            75,
            "DEPENDENCY_DOWNLOAD_FAILED",
            "download failed",
            retryable=True,
        )
        with (
            mock.patch.object(self.manager, "load_marker", return_value=None),
            mock.patch.object(self.manager, "_load_pending_install", return_value=None),
            mock.patch.object(self.manager, "_retained_instance", return_value=None),
            mock.patch.object(self.manager, "_prepare_interactive_secrets"),
            mock.patch.object(self.manager, "_platform_preflight"),
            mock.patch.object(self.manager, "_collision_preflight", return_value=False),
            mock.patch.object(
                self.manager,
                "_service_assets_owned",
                side_effect=[False, True],
            ),
            mock.patch.object(self.manager, "_port_preflight"),
            mock.patch.object(self.manager, "_write_pending_install") as pending,
            mock.patch.object(
                self.manager,
                "_converge_resources",
                side_effect=failure,
            ),
            mock.patch.object(self.manager, "_stop_markerless_services") as stop,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_converge(invocation, configuration)
        self.assertIs(raised.exception, failure)
        pending.assert_called_once()
        stop.assert_called_once_with()
        self.assertIn("rerun install", failure.recovery[-1])

    def test_fresh_port_failure_does_not_stop_unowned_units(self) -> None:
        invocation = management.Invocation(
            operation="install",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        failure = management.ManagementError(73, "PORT_COLLISION", "busy")
        with (
            mock.patch.object(self.manager, "load_marker", return_value=None),
            mock.patch.object(self.manager, "_load_pending_install", return_value=None),
            mock.patch.object(self.manager, "_retained_instance", return_value=None),
            mock.patch.object(self.manager, "_prepare_interactive_secrets"),
            mock.patch.object(self.manager, "_platform_preflight"),
            mock.patch.object(self.manager, "_collision_preflight", return_value=False),
            mock.patch.object(self.manager, "_service_assets_owned", return_value=False),
            mock.patch.object(self.manager, "_port_preflight", side_effect=failure),
            mock.patch.object(self.manager, "_stop_markerless_services") as stop,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_converge(invocation, default_configuration())
        self.assertIs(raised.exception, failure)
        stop.assert_not_called()

    def test_snapshot_failure_restores_prior_service_state(self) -> None:
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        invocation = management.Invocation(
            operation="update",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        configuration = management.Configuration(
            agent_user="beep",
            chat_port=58989,
            provider=None,
            model=None,
            model_base_url=None,
            ttl_days=7,
        )
        failure = management.ManagementError(
            73,
            "UNSAFE_PATH",
            "snapshot failed",
        )
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": True, "enabled": True},
                "beep-health.timer": {"active": True, "enabled": True},
            },
        }
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_prepare_interactive_secrets"),
            mock.patch.object(self.manager, "_platform_preflight"),
            mock.patch.object(self.manager, "_collision_preflight", return_value=False),
            mock.patch.object(self.manager, "_port_preflight"),
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(
                self.manager,
                "_create_recovery_snapshot",
                side_effect=failure,
            ),
            mock.patch.object(self.manager, "_stop_services") as stop,
            mock.patch.object(self.manager, "_restore_service_state") as restore,
            mock.patch.object(self.manager, "_converge_resources") as converge,
            mock.patch.object(self.manager, "_execute_rollback") as rollback,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_converge(invocation, configuration)
        self.assertIs(raised.exception, failure)
        stop.assert_called_once_with()
        restore.assert_called_once_with(service_state)
        converge.assert_not_called()
        rollback.assert_not_called()
        self.assertIn("service state was restored", failure.recovery[-1])

    def test_recovery_snapshot_records_missing_managed_roots(self) -> None:
        self.manager.paths.state_root.mkdir(parents=True)
        correlation_id = "047fd8bd-ed5f-49f9-8da5-07bfe4ebad14"
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        service_state = {
            "schema_version": 1,
            "systemctl": False,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        with mock.patch.object(self.manager, "load_marker", return_value=marker):
            snapshot = self.manager._create_recovery_snapshot(
                correlation_id,
                service_state,
            )
        metadata = management.load_json(snapshot / "snapshot.json")
        self.assertEqual(
            metadata["root_presence"],
            {"opt": False, "home": False, "etc": False, "state": True},
        )
        self.assertEqual(metadata["service_state"], service_state)
        self.assertNotIn("opt", metadata["tree_digests"])
        self.assertNotIn("home", metadata["tree_digests"])
        self.assertNotIn("etc", metadata["tree_digests"])
        self.assertIn("state", metadata["tree_digests"])

    def test_duplicate_recovery_id_preserves_existing_snapshot(self) -> None:
        self.manager.paths.state_root.mkdir(parents=True)
        os.chmod(self.manager.paths.state_root, 0o755)
        correlation_id = "047fd8bd-ed5f-49f9-8da5-07bfe4ebad14"
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        service_state = {
            "schema_version": 1,
            "systemctl": False,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        with mock.patch.object(self.manager, "load_marker", return_value=marker):
            snapshot = self.manager._create_recovery_snapshot(
                correlation_id,
                service_state,
            )
            original = (snapshot / "snapshot.json").read_bytes()
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._create_recovery_snapshot(
                    correlation_id,
                    service_state,
                )
        self.assertEqual(raised.exception.code, "RECOVERY_SNAPSHOT_EXISTS")
        self.assertEqual((snapshot / "snapshot.json").read_bytes(), original)
        self.assertEqual(
            (self.manager.paths.rollback_root / "latest").read_text(encoding="utf-8").strip(),
            correlation_id,
        )

    def test_rollback_apply_failure_restores_every_live_tree(self) -> None:
        service_state = {
            "schema_version": 1,
            "systemctl": False,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        managed = (
            self.manager.paths.install_root,
            self.manager.paths.account_home,
            self.manager.paths.configuration_root,
        )
        for root in (*managed, self.manager.paths.state_root):
            root.mkdir(parents=True)
            os.chmod(root, 0o755)
            (root / "value").write_text("snapshot\n", encoding="utf-8")
        with mock.patch.object(self.manager, "load_marker", return_value=marker):
            snapshot = self.manager._create_recovery_snapshot(
                "047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
                service_state,
            )
        metadata = management.load_json(snapshot / "snapshot.json")
        for root in (*managed, self.manager.paths.state_root):
            (root / "value").write_text("current\n", encoding="utf-8")
        for host_path in self.manager._host_resources():
            host_path.parent.mkdir(parents=True, exist_ok=True)

        real_replace = management.os.replace

        def fail_during_third_root(source: object, destination: object) -> None:
            source_path = Path(source)
            destination_path = Path(destination)
            if (
                destination_path == self.manager.paths.configuration_root
                and ".beep-rollback-new-" in source_path.name
            ):
                raise OSError("injected rename failure")
            real_replace(source, destination)

        with (
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_stop_services"),
            mock.patch.object(self.manager, "_restore_service_state") as restore,
            mock.patch.object(
                management.os,
                "replace",
                side_effect=fail_during_third_root,
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._restore_snapshot_transactionally(
                    snapshot,
                    metadata,
                    [],
                    allow_degraded=False,
                )

        self.assertEqual(raised.exception.code, "ROLLBACK_APPLY_FAILED")
        for root in (*managed, self.manager.paths.state_root):
            self.assertEqual(
                (root / "value").read_text(encoding="utf-8"),
                "current\n",
            )
        restore.assert_called_once_with(service_state)
        leftovers = [
            path
            for path in self.root.rglob("*")
            if ".beep-rollback-" in path.name
        ]
        self.assertEqual(leftovers, [])
        self.assertTrue(snapshot.is_dir())

    def test_rollback_health_failure_restores_pre_rollback_state(self) -> None:
        service_state = {
            "schema_version": 1,
            "systemctl": False,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        snapshot = self.root / "snapshot"
        metadata: dict[str, object] = {
            "root_presence": {
                "opt": True,
                "home": True,
                "etc": True,
                "state": True,
            },
            "tree_digests": {},
            "host_files": [],
            "ownership": {},
            "service_state": service_state,
        }
        for name, live in (
            ("opt", self.manager.paths.install_root),
            ("home", self.manager.paths.account_home),
            ("etc", self.manager.paths.configuration_root),
            ("state", self.manager.paths.state_root),
        ):
            source = snapshot / name
            source.mkdir(parents=True)
            (source / "value").write_text("snapshot\n", encoding="utf-8")
            live.mkdir(parents=True)
            (live / "value").write_text("current\n", encoding="utf-8")
            metadata["tree_digests"][name] = self.manager._tree_digest(source)
        initial_state_mode = stat.S_IMODE(
            self.manager.paths.state_root.lstat().st_mode
        )
        for host_path in self.manager._host_resources():
            host_path.parent.mkdir(parents=True, exist_ok=True)
        health_failure = management.ManagementError(
            1,
            "ROLLBACK_HEALTH_FAILED",
            "injected restored health failure",
        )

        def damage_state_root(_changed: list[str]) -> None:
            os.chmod(self.manager.paths.state_root, 0o700)

        with (
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_stop_services") as stop,
            mock.patch.object(self.manager, "_restore_snapshot_ownership"),
            mock.patch.object(
                self.manager,
                "_secure_state_control_root",
                side_effect=damage_state_root,
            ),
            mock.patch.object(
                self.manager,
                "_complete_rollback",
                side_effect=health_failure,
            ),
            mock.patch.object(self.manager, "_restore_service_state") as restore,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._restore_snapshot_transactionally(
                    snapshot,
                    metadata,
                    [],
                    allow_degraded=False,
                )
        self.assertIs(raised.exception, health_failure)
        for live in (
            self.manager.paths.install_root,
            self.manager.paths.account_home,
            self.manager.paths.configuration_root,
            self.manager.paths.state_root,
        ):
            self.assertEqual(
                (live / "value").read_text(encoding="utf-8"),
                "current\n",
            )
        restore.assert_not_called()
        self.assertGreaterEqual(stop.call_count, 2)
        self.assertIn("remain stopped", health_failure.recovery[-1])
        self.assertEqual(
            stat.S_IMODE(self.manager.paths.state_root.lstat().st_mode),
            initial_state_mode,
        )

    def test_failed_automatic_rollback_never_restarts_failed_services(self) -> None:
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": True, "enabled": True},
                "beep-health.timer": {"active": True, "enabled": True},
            },
        }
        snapshot = self.root / "snapshot"
        metadata: dict[str, object] = {
            "root_presence": {
                "opt": True,
                "home": True,
                "etc": True,
                "state": True,
            },
            "tree_digests": {},
            "host_files": [],
            "ownership": {},
            "service_state": service_state,
        }
        for name, live in (
            ("opt", self.manager.paths.install_root),
            ("home", self.manager.paths.account_home),
            ("etc", self.manager.paths.configuration_root),
            ("state", self.manager.paths.state_root),
        ):
            source = snapshot / name
            source.mkdir(parents=True)
            (source / "value").write_text("snapshot\n", encoding="utf-8")
            live.mkdir(parents=True)
            (live / "value").write_text("current\n", encoding="utf-8")
            metadata["tree_digests"][name] = self.manager._tree_digest(source)
        for host_path in self.manager._host_resources():
            host_path.parent.mkdir(parents=True, exist_ok=True)
        with (
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_stop_services") as stop,
            mock.patch.object(self.manager, "_restore_service_state") as restore,
            mock.patch.object(
                self.manager,
                "_apply_rollback_swaps",
                side_effect=OSError("injected rollback apply failure"),
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._restore_snapshot_transactionally(
                    snapshot,
                    metadata,
                    [],
                    allow_degraded=True,
                )
        self.assertEqual(raised.exception.code, "ROLLBACK_APPLY_FAILED")
        self.assertEqual(stop.call_count, 2)
        restore.assert_not_called()

    def test_rollback_with_present_host_asset_keeps_snapshot_metadata(self) -> None:
        correlation_id = "047fd8bd-ed5f-49f9-8da5-07bfe4ebad14"
        instance_id = "12d515dc-92f6-44d8-adf1-2ca812197307"
        marker = {"instance_id": instance_id, "version": self.manager.version}
        service_state = {
            "schema_version": 1,
            "systemctl": False,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        snapshot_metadata = {
            "schema_version": 1,
            "product_id": "beep",
            "correlation_id": correlation_id,
            "instance_id": instance_id,
            "created_at": "2026-08-11T00:00:00Z",
            "version": self.manager.version,
            "root_presence": {
                "opt": False,
                "home": False,
                "etc": False,
                "state": True,
            },
            "service_state": service_state,
            "tree_digests": {"state": "digest"},
            "host_files": [],
            "ownership": {"state": [os.geteuid(), os.getegid()]},
        }
        snapshot = self.manager.paths.rollback_root / correlation_id
        snapshot.mkdir(parents=True)
        (snapshot / "snapshot.json").write_bytes(
            management.canonical_json(snapshot_metadata) + b"\n"
        )
        latest = self.manager.paths.rollback_root / "latest"
        latest.write_text(f"{correlation_id}\n", encoding="utf-8")
        os.chmod(latest, 0o600)
        self.manager.paths.chat_unit.parent.mkdir(parents=True)
        self.manager.paths.chat_unit.write_text("owned\n", encoding="utf-8")
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(self.manager, "_prepare_recovery_root"),
            mock.patch.object(self.manager, "_assert_tree_safe"),
            mock.patch.object(self.manager, "_validate_snapshot_ownership"),
            mock.patch.object(self.manager, "_tree_digest", return_value="digest"),
            mock.patch.object(
                self.manager,
                "_restore_snapshot_transactionally",
            ) as restore,
            mock.patch.object(self.manager, "_complete_rollback"),
        ):
            self.manager._execute_rollback()
        self.assertIsInstance(restore.call_args.args[1], dict)
        self.assertEqual(restore.call_args.args[1], snapshot_metadata)

    def test_recovery_root_symlink_is_rejected_without_touching_target(self) -> None:
        self.manager.paths.state_root.mkdir(parents=True)
        external = self.root / "external-recovery"
        external.mkdir()
        sentinel = external / "keep"
        sentinel.write_text("keep\n", encoding="utf-8")
        try:
            self.manager.paths.rollback_root.symlink_to(external, target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        with self.assertRaises(management.ManagementError) as raised:
            self.manager._prepare_recovery_root(create=True)
        self.assertIn(raised.exception.code, {"UNSAFE_PATH", "UNSAFE_RECOVERY_ROOT"})
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")

    def test_markerless_health_checks_require_active_services(self) -> None:
        with (
            mock.patch.object(self.manager, "load_marker", return_value=None),
            mock.patch.object(
                self.manager,
                "_lifecycle_status",
                return_value={
                    "configured": True,
                    "dead": False,
                    "dead_reason": None,
                    "remaining_seconds": 60,
                },
            ),
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(
                self.manager,
                "_service_active",
                side_effect=[True, False],
            ),
        ):
            checks = self.manager.checks_without_marker()
        service = next(check for check in checks if check["id"] == "service_state")
        self.assertEqual(service["status"], "fail")

    def test_directory_convergence_rejects_regular_file(self) -> None:
        self.manager.paths.install_root.parent.mkdir(parents=True)
        self.manager.paths.install_root.write_text("collision", encoding="utf-8")
        with mock.patch.object(management.os, "chown"):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._ensure_directories(1000, 1000, [])
        self.assertEqual(raised.exception.code, "UNSAFE_PATH")

    def test_directory_convergence_keeps_lifecycle_parent_root_controlled(self) -> None:
        with (
            mock.patch.object(management.os, "chown") as chown,
            mock.patch.object(self.manager, "_ensure_audit_log"),
        ):
            self.manager._ensure_directories(1000, 1000, [])
        self.assertIn(
            mock.call(self.manager.paths.state_root, 0, 0),
            chown.mock_calls,
        )
        self.assertEqual(
            stat.S_IMODE(self.manager.paths.state_root.stat().st_mode),
            0o755,
        )

    def test_python_environment_removes_standard_lib64_symlink(self) -> None:
        virtualenv = self.manager.paths.account_home / "agent-env"
        (virtualenv / "lib").mkdir(parents=True)
        try:
            (virtualenv / "lib64").symlink_to("lib", target_is_directory=True)
        except OSError as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        self.assertTrue(self.manager._normalize_python_environment(virtualenv))
        self.assertFalse((virtualenv / "lib64").exists())
        self.manager._assert_tree_safe(virtualenv)

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

    def test_node_archive_materializes_npm_link_as_launcher(self) -> None:
        archive = self.root / "node.tar.xz"
        prefix = f"node-v{management.NODE_VERSION}-linux-x64"
        command_name = f"{prefix}/lib/node_modules/npm/bin/npm-cli.js"
        command = b"#!/usr/bin/env node\n"
        with tarfile.open(archive, "w:xz") as output:
            command_info = tarfile.TarInfo(command_name)
            command_info.mode = 0o755
            command_info.size = len(command)
            output.addfile(command_info, io.BytesIO(command))
            link_info = tarfile.TarInfo(f"{prefix}/bin/npm")
            link_info.type = tarfile.SYMTYPE
            link_info.linkname = "../lib/node_modules/npm/bin/npm-cli.js"
            output.addfile(link_info)
        destination = self.root / "node"
        self.manager._extract_node_archive(archive, destination)
        launcher = destination / "bin" / "npm"
        self.assertTrue(launcher.is_file())
        self.assertFalse(launcher.is_symlink())
        content = launcher.read_text(encoding="utf-8")
        self.assertIn("node_modules/npm/bin/npm-cli.js", content)
        self.assertIn('"$@"', content)

    def test_node_runtime_requires_working_npm(self) -> None:
        node = self.manager.paths.node_root / "bin" / "node"
        npm = self.manager.paths.node_root / "bin" / "npm"
        node.parent.mkdir(parents=True)
        for path in (node, npm):
            path.write_text("#!/bin/sh\n", encoding="utf-8")
            os.chmod(path, 0o755)
        marker = self.manager.paths.node_root / ".beep-node.json"
        marker.write_bytes(
            management.canonical_json(
                {
                    "archive": management.NODE_ARCHIVE,
                    "schema_version": 1,
                    "sha256": management.NODE_SHA256,
                    "version": management.NODE_VERSION,
                    "runtime_digest": self.manager._node_base_digest(
                        self.manager.paths.node_root
                    ),
                }
            )
            + b"\n"
        )
        responses = (
            subprocess.CompletedProcess([], 0, f"v{management.NODE_VERSION}\n", ""),
            subprocess.CompletedProcess([], 1, "", "broken npm"),
        )
        with mock.patch.object(self.manager, "_run", side_effect=responses):
            self.assertFalse(self.manager._node_runtime_supported())

    def test_unsafe_node_runtime_is_rejected_before_execution(self) -> None:
        node = self.manager.paths.node_root / "bin" / "node"
        node.parent.mkdir(parents=True)
        node.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        os.chmod(node, 0o777)
        with (
            mock.patch.object(self.manager, "_run") as run,
            mock.patch.object(self.manager, "_download_dependency") as download,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._ensure_node_runtime([])
        self.assertEqual(raised.exception.code, "UNSAFE_PATH")
        run.assert_not_called()
        download.assert_not_called()

    def test_node_runtime_digest_rejects_corrupted_binary_before_execution(self) -> None:
        node = self.manager.paths.node_root / "bin" / "node"
        npm = self.manager.paths.node_root / "bin" / "npm"
        node.parent.mkdir(parents=True)
        for path in (node, npm):
            path.write_text("#!/bin/sh\n", encoding="utf-8")
            os.chmod(path, 0o755)
        marker = self.manager.paths.node_root / ".beep-node.json"
        marker.write_bytes(
            management.canonical_json(
                {
                    "archive": management.NODE_ARCHIVE,
                    "schema_version": 1,
                    "sha256": management.NODE_SHA256,
                    "version": management.NODE_VERSION,
                    "runtime_digest": self.manager._node_base_digest(
                        self.manager.paths.node_root
                    ),
                }
            )
            + b"\n"
        )
        node.write_text("#!/bin/sh\necho corrupted\n", encoding="utf-8")
        os.chmod(node, 0o755)
        with mock.patch.object(self.manager, "_run") as run:
            self.assertFalse(self.manager._node_runtime_supported())
        run.assert_not_called()

    def test_dependency_download_retries_transient_failure(self) -> None:
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.geturl.return_value = "https://nodejs.org/runtime.tar.xz"
        response.read.return_value = b"verified bytes"
        with (
            mock.patch.object(
                management.urllib.request,
                "urlopen",
                side_effect=[OSError("temporary failure"), response],
            ) as open_url,
            mock.patch.object(management.time, "sleep") as sleep,
        ):
            value = self.manager._download_dependency(
                "https://nodejs.org/runtime.tar.xz",
                hostname="nodejs.org",
                maximum_bytes=1024,
                label="test runtime",
            )
        self.assertEqual(value, b"verified bytes")
        self.assertEqual(open_url.call_count, 2)
        sleep.assert_called_once_with(management.DEPENDENCY_RETRY_SECONDS)

    def test_dependency_command_waits_for_apt_lock(self) -> None:
        locked = subprocess.CompletedProcess(
            [],
            100,
            "",
            "Could not get lock /var/lib/dpkg/lock-frontend",
        )
        succeeded = subprocess.CompletedProcess([], 0, "", "")
        with (
            mock.patch.object(self.manager, "_run", side_effect=[locked, succeeded]) as run,
            mock.patch.object(management.time, "monotonic", side_effect=[0.0, 1.0]),
            mock.patch.object(management.time, "sleep") as sleep,
        ):
            result = self.manager._run_dependency_command(
                ["apt-get", "update"],
                environment={"DEBIAN_FRONTEND": "noninteractive"},
            )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(management.DEPENDENCY_RETRY_SECONDS)

    def test_bridge_tree_digest_detects_transitive_corruption(self) -> None:
        modules = self.manager.paths.node_root / "lib" / "node_modules"
        dependency = modules / "dependency" / "index.js"
        dependency.parent.mkdir(parents=True)
        dependency.write_text("export const value = 1;\n", encoding="utf-8")
        pins = [
            (
                "@earendil-works/pi-ai",
                "0.80.10",
                "https://registry.npmjs.org/pi-ai.tgz",
                "0" * 64,
                "sha512-AA==",
            )
        ]
        marker = self.manager._bridge_marker_value(pins)
        self.manager.paths.bridge_marker.write_bytes(
            management.canonical_json(marker) + b"\n"
        )
        os.chmod(self.manager.paths.bridge_marker, 0o644)
        self.assertTrue(self.manager._bridge_tree_valid(pins))
        dependency.write_text("export const value = 2;\n", encoding="utf-8")
        self.assertFalse(self.manager._bridge_tree_valid(pins))

    def test_complete_bridge_lock_rejects_an_external_registry(self) -> None:
        pins = self.manager._bridge_pins()
        manifest = management.load_json(
            PRODUCT_ROOT / "payload" / "agent" / "bridge-package.json"
        )
        package_lock = management.load_json(
            PRODUCT_ROOT / "payload" / "agent" / "bridge-package-lock.json"
        )
        package_lock["packages"]["node_modules/zod"]["resolved"] = (
            "https://packages.example.invalid/zod.tgz"
        )
        with mock.patch.object(
            management,
            "load_json",
            side_effect=[manifest, package_lock],
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._validate_bridge_package_lock(pins)
        self.assertEqual(raised.exception.code, "INVALID_DEPENDENCY_LOCK")

    def test_node_launcher_replaces_npm_symlink_with_regular_file(self) -> None:
        package = (
            self.manager.paths.node_root
            / "lib"
            / "node_modules"
            / "@earendil-works"
            / "pi-coding-agent"
        )
        command = package / "dist" / "cli.js"
        command.parent.mkdir(parents=True)
        command.write_text("#!/usr/bin/env node\n", encoding="utf-8")
        os.chmod(command, 0o755)
        (package / "package.json").write_text(
            '{"name":"@earendil-works/pi-coding-agent",'
            '"version":"0.80.10","bin":{"pi":"dist/cli.js"}}\n',
            encoding="utf-8",
        )
        node = self.manager.paths.node_root / "bin" / "node"
        node.parent.mkdir(parents=True)
        node.write_text("#!/bin/sh\n", encoding="utf-8")
        link = self.manager.paths.node_root / "bin" / "pi"
        try:
            link.symlink_to(
                "../lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
            )
        except OSError as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        changed: list[str] = []
        self.manager._ensure_node_launchers(
            [
                (
                    "@earendil-works/pi-coding-agent",
                    "0.80.10",
                    "https://registry.npmjs.org/pi.tgz",
                    "0" * 64,
                    "sha512-AA==",
                )
            ],
            changed,
        )
        self.assertTrue(link.is_file())
        self.assertFalse(link.is_symlink())
        self.assertIn(str(command), link.read_text(encoding="utf-8"))
        self.assertIn(str(link), changed)

    def test_service_stop_requires_units_to_be_inactive_and_disabled(self) -> None:
        with (
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(self.manager, "_run"),
            mock.patch.object(self.manager, "_service_active", return_value=False),
            mock.patch.object(self.manager, "_service_enabled", return_value=True),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._stop_services()
        self.assertEqual(raised.exception.code, "SERVICE_STOP_FAILED")

    def test_service_start_requires_units_to_be_active_and_enabled(self) -> None:
        changed: list[str] = []
        with (
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(self.manager, "_run"),
            mock.patch.object(self.manager, "_service_active", return_value=False),
            mock.patch.object(self.manager, "_service_enabled", return_value=True),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._start_services(changed, suspended=False)
        self.assertEqual(raised.exception.code, "SERVICE_START_FAILED")
        self.assertEqual(changed, [])

    def test_service_stop_waits_for_running_health_oneshot(self) -> None:
        with (
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(self.manager, "_run") as run,
            mock.patch.object(
                self.manager,
                "_service_active",
                side_effect=[False, False, True],
            ),
            mock.patch.object(self.manager, "_service_enabled", return_value=False),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._stop_services()
        self.assertEqual(raised.exception.code, "SERVICE_STOP_FAILED")
        self.assertIn(
            mock.call(["systemctl", "stop", "beep-health.service"], check=False),
            run.mock_calls,
        )

    def test_markerless_stop_does_not_touch_unit_names_without_assets(self) -> None:
        self.manager.paths.chat_unit.parent.mkdir(parents=True)
        self.manager.paths.chat_unit.write_text("owned\n", encoding="utf-8")
        with (
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(self.manager, "_run") as run,
            mock.patch.object(self.manager, "_service_active", return_value=False),
            mock.patch.object(self.manager, "_service_enabled", return_value=False),
        ):
            self.manager._stop_markerless_services()
        run.assert_called_once_with(
            ["systemctl", "disable", "--now", "beep-chat.service"],
            check=False,
        )

    def test_markerless_stop_attempts_every_owned_unit_after_a_failure(self) -> None:
        for path in (
            self.manager.paths.chat_unit,
            self.manager.paths.health_unit,
            self.manager.paths.health_timer,
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("owned\n", encoding="utf-8")
        with (
            mock.patch.object(management.shutil, "which", return_value="systemctl"),
            mock.patch.object(self.manager, "_run") as run,
            mock.patch.object(
                self.manager,
                "_service_active",
                side_effect=lambda unit: unit == "beep-health.timer",
            ),
            mock.patch.object(self.manager, "_service_enabled", return_value=False),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._stop_markerless_services()
        self.assertEqual(raised.exception.code, "SERVICE_STOP_FAILED")
        self.assertIn(
            mock.call(
                ["systemctl", "disable", "--now", "beep-chat.service"],
                check=False,
            ),
            run.mock_calls,
        )
        self.assertIn(
            mock.call(
                ["systemctl", "stop", "beep-health.service"],
                check=False,
            ),
            run.mock_calls,
        )

    def test_suspend_write_failure_restores_prior_service_state(self) -> None:
        marker = {"version": self.manager.version}
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": True, "enabled": True},
                "beep-health.timer": {"active": True, "enabled": True},
            },
        }
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_stop_services"),
            mock.patch.object(self.manager, "_restore_service_state") as restore,
            mock.patch.object(
                management,
                "atomic_write",
                side_effect=OSError("injected write failure"),
            ),
        ):
            with self.assertRaises(OSError):
                self.manager._execute_suspend()
        restore.assert_called_once_with(service_state)

    def test_resume_start_failure_keeps_suspension_and_restores_services(self) -> None:
        marker = {"version": self.manager.version}
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": False, "enabled": False},
                "beep-health.timer": {"active": False, "enabled": False},
            },
        }
        self.manager.paths.state_root.mkdir(parents=True)
        self.manager.paths.suspended.write_text("{}\n", encoding="utf-8")
        failure = management.ManagementError(1, "COMMAND_FAILED", "start failed")
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(
                self.manager,
                "_lifecycle_status",
                return_value={"dead": False},
            ),
            mock.patch.object(self.manager, "checks", return_value=[]),
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_start_services", side_effect=failure),
            mock.patch.object(self.manager, "_restore_service_state") as restore,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_resume()
        self.assertIs(raised.exception, failure)
        self.assertTrue(self.manager.paths.suspended.is_file())
        restore.assert_called_once_with(service_state)

    def test_backup_restore_failure_removes_uncommitted_archive(self) -> None:
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": True, "enabled": True},
                "beep-health.timer": {"active": True, "enabled": True},
            },
        }
        for root in (
            self.manager.paths.account_home,
            self.manager.paths.configuration_root,
            self.manager.paths.state_root,
            self.manager.paths.log_root,
        ):
            root.mkdir(parents=True)
            (root / "value").write_text("data\n", encoding="utf-8")
        destination = self.root / "backups"
        invocation = management.Invocation(
            operation="backup",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={"backup_destination": str(destination)},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        restore_failure = management.ManagementError(
            1,
            "SERVICE_RESTORE_FAILED",
            "restore failed",
        )
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(self.manager, "_assert_account_home_migratable"),
            mock.patch.object(self.manager, "_materialize_python_environment_links"),
            mock.patch.object(
                self.manager,
                "_capture_service_state",
                return_value=service_state,
            ),
            mock.patch.object(self.manager, "_stop_services"),
            mock.patch.object(
                self.manager,
                "_restore_service_state",
                side_effect=restore_failure,
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_backup(invocation)
        self.assertEqual(raised.exception.code, "SERVICE_RESTORE_FAILED")
        self.assertEqual(list(destination.iterdir()), [])

    def test_failed_explicit_rollback_always_stops_restored_services(self) -> None:
        service_state = {
            "schema_version": 1,
            "systemctl": True,
            "units": {
                "beep-chat.service": {"active": True, "enabled": True},
                "beep-health.timer": {"active": True, "enabled": True},
            },
        }
        restored = mock.Mock()
        restored.checks.return_value = [
            {"id": "runtime", "status": "fail", "summary": "broken"}
        ]
        with (
            mock.patch.object(management, "Manager", return_value=restored),
            mock.patch.object(self.manager, "_restore_service_state") as restore,
            mock.patch.object(self.manager, "_stop_services") as stop,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._complete_rollback(
                    service_state,
                    allow_degraded=False,
                )
        self.assertEqual(raised.exception.code, "ROLLBACK_HEALTH_FAILED")
        restore.assert_not_called()
        stop.assert_called_once_with()

    def test_uninstall_preflight_does_not_remove_earlier_safe_assets(self) -> None:
        self.manager.paths.log_root.mkdir(parents=True)
        os.chmod(self.manager.paths.log_root, 0o755)
        self.manager.paths.receipts.mkdir()
        os.chmod(self.manager.paths.receipts, 0o750)
        self.manager.paths.chat_unit.parent.mkdir(parents=True)
        self.manager.paths.chat_unit.write_text("safe\n", encoding="utf-8")
        os.chmod(self.manager.paths.chat_unit, 0o644)
        self.manager.paths.health_unit.mkdir()
        invocation = management.Invocation(
            operation="uninstall",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=True,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_stop_services") as stop,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_uninstall(invocation)
        self.assertEqual(raised.exception.code, "UNSAFE_PATH")
        self.assertTrue(self.manager.paths.chat_unit.is_file())
        stop.assert_not_called()

    def test_receipt_symlink_does_not_escape_the_log_root(self) -> None:
        self.manager.paths.log_root.mkdir(parents=True)
        os.chmod(self.manager.paths.log_root, 0o755)
        external = self.root / "external-receipts"
        external.mkdir()
        sentinel = external / "keep"
        sentinel.write_text("keep\n", encoding="utf-8")
        try:
            self.manager.paths.receipts.symlink_to(
                external,
                target_is_directory=True,
            )
        except OSError as exc:
            self.skipTest(f"symbolic links are unavailable: {exc}")
        result = management.Result(
            operation="suspend",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            product_version=self.manager.version,
            instance_id="12d515dc-92f6-44d8-adf1-2ca812197307",
            phase="execute",
        )
        with self.assertRaises(management.ManagementError) as raised:
            self.manager._write_receipt(
                result,
                previous_version=self.manager.version,
                changed_resources=[],
                event_id="f8071307-88ee-453c-9eb0-f2a91cd46b30",
            )
        self.assertEqual(raised.exception.code, "UNSAFE_RECEIPT_PATH")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep\n")
        self.assertEqual(list(external.iterdir()), [sentinel])

    def test_fresh_purge_rejects_group_without_managed_user(self) -> None:
        with (
            mock.patch.object(
                management.pwd,
                "getpwnam",
                side_effect=KeyError("beep"),
            ),
            mock.patch.object(
                management.grp,
                "getgrnam",
                return_value=types.SimpleNamespace(gr_gid=1200),
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._validate_purge_identity(None)
        self.assertEqual(raised.exception.code, "IDENTITY_COLLISION")

    def test_purge_state_round_trip_records_exact_identity(self) -> None:
        if os.name == "nt":
            self.skipTest("Windows cannot represent POSIX file mode 0600")
        self.manager.paths.state_root.parent.mkdir(parents=True)
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        identity = {"user_uid": 1200, "user_gid": 1200, "group_gid": 1200}
        self.assertTrue(self.manager._write_purge_state(marker, identity))
        self.assertEqual(self.manager._load_purge_state()["identity"], identity)
        self.assertEqual(
            stat.S_IMODE(self.manager.paths.purge_state.lstat().st_mode),
            0o600,
        )

    def test_markerless_interrupted_purge_resumes_without_vendor_unit_names(self) -> None:
        invocation = management.Invocation(
            operation="uninstall",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=management.DELETE_CONFIRMATION,
            retain_state=False,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        state = purge_state(self.manager)
        with (
            mock.patch.object(self.manager, "load_marker", return_value=None),
            mock.patch.object(self.manager, "_load_purge_state", return_value=state),
            mock.patch.object(
                self.manager,
                "_preflight_uninstall",
                return_value=state["identity"],
            ),
            mock.patch.object(self.manager, "_ensure_purge_evidence_roots"),
            mock.patch.object(self.manager, "_stop_markerless_services") as stop,
            mock.patch.object(self.manager, "_stop_services") as broad_stop,
            mock.patch.object(self.manager, "_path_present", return_value=False),
            mock.patch.object(management.shutil, "which", return_value=None),
        ):
            changed, previous = self.manager._execute_uninstall(invocation)
        self.assertEqual(changed, [])
        self.assertEqual(previous, self.manager.version)
        stop.assert_called_once_with()
        broad_stop.assert_not_called()

    def test_interrupted_purge_blocks_every_other_mutation(self) -> None:
        invocation = management.Invocation(
            operation="rollback",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        with mock.patch.object(
            self.manager,
            "_load_purge_state",
            return_value=purge_state(self.manager),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._enforce_purge_boundary(invocation)
        self.assertEqual(raised.exception.code, "PURGE_IN_PROGRESS")

    def test_partial_state_root_purge_keeps_resumption_tombstone(self) -> None:
        if os.name == "nt":
            self.skipTest("Windows cannot represent POSIX file mode 0600")
        self.manager.paths.state_root.parent.mkdir(parents=True)
        marker_value = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        self.manager._write_purge_state(
            marker_value,
            {"user_uid": None, "user_gid": None, "group_gid": None},
        )
        for root in (
            self.manager.paths.configuration_root,
            self.manager.paths.state_root,
            self.manager.paths.log_root,
        ):
            root.mkdir(parents=True)
        self.manager.paths.marker.write_text("partial\n", encoding="utf-8")
        real_rmtree = management.shutil.rmtree

        def fail_during_state_removal(path: object) -> None:
            target = Path(path)
            if target == self.manager.paths.state_root:
                self.manager.paths.marker.unlink()
                raise OSError("injected state removal failure")
            real_rmtree(target)

        with (
            mock.patch.object(self.manager, "_validate_purge_identity"),
            mock.patch.object(
                management.pwd,
                "getpwnam",
                side_effect=KeyError("beep"),
            ),
            mock.patch.object(
                management.grp,
                "getgrnam",
                side_effect=KeyError("beep"),
            ),
            mock.patch.object(
                management.shutil,
                "rmtree",
                side_effect=fail_during_state_removal,
            ),
        ):
            with self.assertRaises(OSError):
                self.manager._finalize_purge()
        self.assertFalse(self.manager.paths.marker.exists())
        self.assertEqual(
            self.manager._load_purge_state()["instance_id"],
            marker_value["instance_id"],
        )

    def test_failed_purge_records_no_completed_success_evidence(self) -> None:
        invocation = management.Invocation(
            operation="uninstall",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=management.DELETE_CONFIRMATION,
            retain_state=False,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        failure = management.ManagementError(
            1,
            "IDENTITY_REMOVE_FAILED",
            "userdel failed",
        )
        with (
            mock.patch.object(self.manager, "steps", return_value=[]),
            mock.patch.object(self.manager, "plan_digest", return_value="sha256:test"),
            mock.patch.object(self.manager, "instance_id", return_value="instance"),
            mock.patch.object(self.manager, "_required_inputs", return_value=[]),
            mock.patch.object(self.manager, "_confirm"),
            mock.patch.object(management.os, "geteuid", return_value=0),
            mock.patch.object(self.manager, "_lock"),
            mock.patch.object(self.manager, "_validate_source"),
            mock.patch.object(
                self.manager,
                "_execute_uninstall",
                return_value=(["/opt/beep"], self.manager.version),
            ),
            mock.patch.object(
                self.manager,
                "_write_receipt",
                return_value={"path": "/receipt", "digest": "sha256:receipt"},
            ),
            mock.patch.object(self.manager, "_append_audit") as audit,
            mock.patch.object(self.manager, "_journal_purge_evidence") as journal,
            mock.patch.object(self.manager, "_finalize_purge", side_effect=failure),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager.run(invocation)
        self.assertIs(raised.exception, failure)
        audit.assert_called_once()
        self.assertEqual(audit.call_args.args[1].status, "in_progress")
        journal.assert_called_once()
        self.assertEqual(journal.call_args.kwargs["phase"], "purge_started")

    def test_failed_existing_convergence_restores_recovery_snapshot(self) -> None:
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        invocation = management.Invocation(
            operation="update",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        configuration = management.Configuration(
            agent_user="beep",
            chat_port=58989,
            provider=None,
            model=None,
            model_base_url=None,
            ttl_days=7,
        )
        failure = management.ManagementError(
            1,
            "DEPLOYMENT_FAILED",
            "deployment failed",
        )
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_platform_preflight"),
            mock.patch.object(self.manager, "_collision_preflight"),
            mock.patch.object(self.manager, "_port_preflight"),
            mock.patch.object(self.manager, "_prepare_interactive_secrets"),
            mock.patch.object(self.manager, "_stop_services"),
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(self.manager, "_create_recovery_snapshot"),
            mock.patch.object(
                self.manager,
                "_converge_resources",
                side_effect=failure,
            ),
            mock.patch.object(self.manager, "_execute_rollback") as rollback,
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_converge(invocation, configuration)
        self.assertIs(raised.exception, failure)
        rollback.assert_called_once_with(allow_degraded=True)
        self.assertIn("restored automatically", failure.recovery[-1])

    def test_failed_automatic_rollback_is_stopped_again(self) -> None:
        marker = {
            "instance_id": "12d515dc-92f6-44d8-adf1-2ca812197307",
            "version": self.manager.version,
        }
        invocation = management.Invocation(
            operation="update",
            correlation_id="047fd8bd-ed5f-49f9-8da5-07bfe4ebad14",
            actor="operator",
            inputs={},
            confirmation=None,
            retain_state=None,
            dry_run=False,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )
        deployment_failure = management.ManagementError(
            1, "DEPLOYMENT_FAILED", "deployment failed"
        )
        rollback_failure = management.ManagementError(
            1, "ROLLBACK_APPLY_FAILED", "rollback failed"
        )
        with (
            mock.patch.object(self.manager, "load_marker", return_value=marker),
            mock.patch.object(self.manager, "_platform_preflight"),
            mock.patch.object(self.manager, "_collision_preflight"),
            mock.patch.object(self.manager, "_port_preflight"),
            mock.patch.object(self.manager, "_prepare_interactive_secrets"),
            mock.patch.object(self.manager, "_stop_services") as stop,
            mock.patch.object(self.manager, "_secure_state_control_root"),
            mock.patch.object(self.manager, "_create_recovery_snapshot"),
            mock.patch.object(
                self.manager,
                "_converge_resources",
                side_effect=deployment_failure,
            ),
            mock.patch.object(
                self.manager,
                "_execute_rollback",
                side_effect=rollback_failure,
            ),
        ):
            with self.assertRaises(management.ManagementError) as raised:
                self.manager._execute_converge(invocation, default_configuration())
        self.assertEqual(raised.exception.code, "AUTOMATIC_ROLLBACK_FAILED")
        self.assertGreaterEqual(stop.call_count, 2)


if __name__ == "__main__":
    unittest.main()
