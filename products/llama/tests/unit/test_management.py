from __future__ import annotations

import json
import os
import tarfile
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

from llama.management import (
    Configuration,
    Invocation,
    ManagementError,
    Manager,
    Paths,
)


SOURCE_ROOT = Path(__file__).resolve().parents[2]


class ManagementTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.paths = Paths(
            install_root=root / "opt/llama.cpp",
            configuration_root=root / "etc/llama.cpp",
            state_root=root / "var/lib/llama.cpp",
            log_root=root / "var/log/llama.cpp",
            cache_root=root / "var/cache/llama.cpp",
            unit=root / "etc/systemd/system/llama-server.service",
            logrotate=root / "etc/logrotate.d/llama",
            entrypoint=root / "usr/local/sbin/llama-manage",
            manager=root / "usr/local/bin/llama-manager",
            lock=root / "run/lock/llama.lock",
            backup_root=root / "var/backups/llama.cpp",
        )
        self.manager = Manager(SOURCE_ROOT)
        self.manager.paths = self.paths

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def invocation(
        self,
        operation: str = "install",
        *,
        inputs: dict[str, object] | None = None,
        dry_run: bool = False,
    ) -> Invocation:
        return Invocation(
            operation=operation,
            correlation_id=str(uuid.uuid4()),
            actor="operator",
            inputs=inputs or {},
            confirmation=None,
            retain_state=True if operation == "uninstall" else None,
            dry_run=dry_run,
            json_output=True,
            non_interactive=True,
            assume_yes=True,
            supplied_plan_digest=None,
        )

    def test_descriptor_preserves_existing_host_namespace(self) -> None:
        descriptor = self.manager.descriptor
        self.assertEqual(descriptor["install_root"], "/opt/llama.cpp")
        self.assertEqual(descriptor["state_root"], "/var/lib/llama.cpp")
        self.assertEqual(descriptor["accounts"][0]["name"], "llama-cpp")
        self.assertEqual(descriptor["ports"][0]["address"], "127.0.0.1")
        self.assertEqual(descriptor["ports"][0]["port"], 8080)

    def test_default_configuration_uses_pinned_catalogues(self) -> None:
        configuration = self.manager.configuration(self.invocation())
        self.assertEqual(configuration.model_id, "smollm2-360m-instruct-q4_k_m")
        self.assertEqual(configuration.context_size, 2048)
        self.assertEqual(configuration.runtime_release, "b10054")
        self.assertEqual(
            configuration.object()["runtime_dir"], str(self.paths.current)
        )
        self.assertTrue(
            str(configuration.model_path).startswith(str(self.paths.models))
        )

    def test_configuration_rejects_unapproved_model_and_oversized_context(self) -> None:
        with self.assertRaises(ManagementError) as raised:
            self.manager.configuration(
                self.invocation(inputs={"model_id": "unapproved"})
            )
        self.assertEqual(raised.exception.code, "MODEL_NOT_APPROVED")
        with self.assertRaises(ManagementError) as raised:
            self.manager.configuration(
                self.invocation(inputs={"context_size": 4096})
            )
        self.assertEqual(raised.exception.code, "INVALID_CONFIGURATION")

    def test_fixed_port_cannot_be_overridden(self) -> None:
        with mock.patch.dict(os.environ, {"LLAMA_PORT": "8081"}):
            with self.assertRaises(ManagementError) as raised:
                self.manager.configuration(self.invocation())
        self.assertEqual(raised.exception.code, "INVALID_CONFIGURATION")

    def test_dry_run_does_not_create_lock_or_product_paths(self) -> None:
        invocation = self.invocation(dry_run=True)
        result, exit_code = self.manager.run(invocation)
        self.assertEqual(exit_code, 0)
        self.assertEqual(result.phase, "plan")
        self.assertFalse(result.changed)
        self.assertTrue(result.plan_digest.startswith("sha256:"))
        self.assertFalse(self.paths.lock.exists())
        self.assertFalse(self.paths.install_root.exists())

    def test_archive_member_rejects_traversal_and_escaping_link(self) -> None:
        traversal = tarfile.TarInfo("../escape")
        escaping_link = tarfile.TarInfo("root/link")
        escaping_link.type = tarfile.SYMTYPE
        escaping_link.linkname = "../../escape"
        safe = tarfile.TarInfo("root/llama-server")
        self.assertFalse(self.manager._safe_archive_member(traversal))
        self.assertFalse(self.manager._safe_archive_member(escaping_link))
        self.assertTrue(self.manager._safe_archive_member(safe))

    def test_clean_install_writes_marker_only_after_boundary_checks(self) -> None:
        configuration = Configuration(
            "smollm2-360m-instruct-q4_k_m",
            2048,
            2,
            "disabled",
            "b10054",
            self.paths.versions / "b10054-amd64",
            self.paths.models / "SmolLM2-360M-Instruct-Q4_K_M.gguf",
        )
        events: list[str] = []
        names = {
            "_platform_preflight": mock.DEFAULT,
            "_collision_preflight": mock.DEFAULT,
            "_port_preflight": mock.DEFAULT,
            "_ensure_directory": mock.DEFAULT,
            "_ensure_transaction": mock.DEFAULT,
            "_ensure_account": mock.DEFAULT,
            "_deploy_product": mock.DEFAULT,
            "_install_runtime": mock.DEFAULT,
            "_install_model": mock.DEFAULT,
            "_deploy_configuration": mock.DEFAULT,
            "_apply_service_state": mock.DEFAULT,
            "_post_install_checks": mock.DEFAULT,
            "_write_marker": mock.DEFAULT,
        }
        with mock.patch.multiple(self.manager, **names) as patched:
            patched["_collision_preflight"].return_value = (
                None,
                "bfe451ff-ae20-4a45-872f-85a4566dc590",
            )
            patched["_ensure_account"].return_value = (100, 100)
            patched["_post_install_checks"].side_effect = lambda *_args, **_kwargs: (
                events.append("checks") or []
            )
            patched["_write_marker"].side_effect = lambda *_args, **_kwargs: (
                events.append("marker")
            )
            self.manager._execute_install(
                self.invocation(), configuration, snapshot_on_change=True
            )
        self.assertEqual(events, ["checks", "marker"])

    def test_failed_boundary_check_never_writes_marker(self) -> None:
        configuration = Configuration(
            "smollm2-360m-instruct-q4_k_m",
            2048,
            2,
            "disabled",
            "b10054",
            self.paths.versions / "b10054-amd64",
            self.paths.models / "SmolLM2-360M-Instruct-Q4_K_M.gguf",
        )
        names = {
            "_platform_preflight": mock.DEFAULT,
            "_collision_preflight": mock.DEFAULT,
            "_port_preflight": mock.DEFAULT,
            "_ensure_directory": mock.DEFAULT,
            "_ensure_transaction": mock.DEFAULT,
            "_ensure_account": mock.DEFAULT,
            "_deploy_product": mock.DEFAULT,
            "_install_runtime": mock.DEFAULT,
            "_install_model": mock.DEFAULT,
            "_deploy_configuration": mock.DEFAULT,
            "_apply_service_state": mock.DEFAULT,
            "_post_install_checks": mock.DEFAULT,
            "_write_marker": mock.DEFAULT,
        }
        with mock.patch.multiple(self.manager, **names) as patched:
            patched["_collision_preflight"].return_value = (
                None,
                "bfe451ff-ae20-4a45-872f-85a4566dc590",
            )
            patched["_ensure_account"].return_value = (100, 100)
            patched["_post_install_checks"].return_value = [
                self.manager.check(
                    "health", False, "Health failed.", "Inspect the service."
                )
            ]
            with self.assertRaises(ManagementError):
                self.manager._execute_install(
                    self.invocation(), configuration, snapshot_on_change=True
                )
        patched["_write_marker"].assert_not_called()

    def test_backup_destination_cannot_be_inside_product_state(self) -> None:
        invocation = self.invocation(
            "backup",
            inputs={"backup_destination": str(self.paths.state_root / "backup")},
        )
        with self.assertRaises(ManagementError) as raised:
            self.manager._backup_destination(invocation)
        self.assertEqual(raised.exception.code, "INVALID_BACKUP_DESTINATION")

    def test_unknown_operation_input_is_rejected(self) -> None:
        args = mock.Mock(
            operation="resume",
            request_file=None,
            correlation_id=None,
            confirmation=None,
            purge=False,
            non_interactive=False,
            dry_run=False,
            json=True,
            yes=False,
            plan_digest=None,
        )
        request = {
            "schema_version": 1,
            "product_id": "llama",
            "operation": "resume",
            "correlation_id": str(uuid.uuid4()),
            "requested_by": "operator",
            "inputs": {"context_size": 1024},
            "confirmation": None,
        }
        with mock.patch.object(self.manager, "_request", return_value=request):
            args.request_file = Path("/request.json")
            with self.assertRaises(ManagementError) as raised:
                self.manager.invocation(args)
        self.assertEqual(raised.exception.code, "UNKNOWN_INPUT")


if __name__ == "__main__":
    unittest.main()
