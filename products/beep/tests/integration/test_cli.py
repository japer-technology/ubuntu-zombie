from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


PRODUCT_ROOT = Path(__file__).resolve().parents[2]
MANAGER = PRODUCT_ROOT / "scripts" / "manage.sh"
INSTALLER = PRODUCT_ROOT / "scripts" / "install.sh"


def clean_environment() -> dict[str, str]:
    return {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("BEEP_")
    }


class ManagementCLITests(unittest.TestCase):
    def run_manager(
        self,
        *arguments: str,
        environment: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        completed = subprocess.run(
            [str(MANAGER), *arguments, "--json"],
            cwd=PRODUCT_ROOT,
            env=environment or clean_environment(),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return completed, json.loads(completed.stdout)

    def test_describe_uses_family_envelope(self) -> None:
        completed, response = self.run_manager("describe")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(response["product_id"], "beep")
        self.assertEqual(response["operation"], "describe")
        descriptor = response["details"]["beep"]["descriptor"]
        self.assertIn("kill", descriptor["operations"])

    def test_source_manager_uses_its_adjacent_product(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            working_directory = Path(directory)
            decoy = working_directory / "beep"
            decoy.mkdir()
            (decoy / "__init__.py").write_text("", encoding="utf-8")
            (decoy / "management.py").write_text(
                "raise SystemExit(99)\n",
                encoding="utf-8",
            )
            environment = clean_environment()
            environment["BEEP_SOURCE_ROOT"] = directory
            completed = subprocess.run(
                [str(MANAGER), "describe", "--json"],
                cwd=working_directory,
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            response = json.loads(completed.stdout)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(response["product_id"], "beep")
        self.assertEqual(
            response["details"]["beep"]["descriptor"]["source_root"],
            "products/beep",
        )

    @unittest.skipIf(
        Path("/opt/beep/product/payload/agent/beep/management.py").is_file(),
        "host already has an installed Beep product",
    )
    def test_installed_wrapper_does_not_select_adjacent_decoy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            wrapper = root / "usr" / "local" / "sbin" / "beep-manage"
            wrapper.parent.mkdir(parents=True)
            shutil.copy2(MANAGER, wrapper)
            decoy = (
                root
                / "usr"
                / "local"
                / "payload"
                / "agent"
                / "beep"
                / "management.py"
            )
            decoy.parent.mkdir(parents=True)
            decoy.write_text("raise SystemExit(99)\n", encoding="utf-8")
            completed = subprocess.run(
                [str(wrapper), "describe"],
                cwd=PRODUCT_ROOT,
                env=clean_environment(),
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertEqual(completed.returncode, 66, completed.stderr)
        self.assertIn("/opt/beep/product", completed.stderr)

    def test_source_manager_rejects_symlink_before_python_import(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "product"
            wrapper = root / "scripts" / "manage.sh"
            wrapper.parent.mkdir(parents=True)
            shutil.copy2(MANAGER, wrapper)
            management = root / "payload" / "agent" / "beep" / "management.py"
            management.parent.mkdir(parents=True)
            management.write_text("raise SystemExit(99)\n", encoding="utf-8")
            link = root / "payload" / "unsafe-link"
            try:
                link.symlink_to(management)
            except OSError as exc:
                self.skipTest(f"symbolic links are unavailable: {exc}")
            completed = subprocess.run(
                [str(wrapper), "describe"],
                cwd=PRODUCT_ROOT,
                env=clean_environment(),
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        self.assertEqual(completed.returncode, 78, completed.stderr)
        self.assertIn("source contains a symlink", completed.stderr)

    def test_unattended_blocked_plan_returns_usage_status(self) -> None:
        environment = clean_environment()
        environment["BEEP_NONINTERACTIVE"] = "1"
        completed, response = self.run_manager(
            "install",
            "--dry-run",
            environment=environment,
        )
        self.assertEqual(completed.returncode, 64)
        self.assertEqual(response["status"], "blocked")
        self.assertIn(
            "chat_password_file",
            {item["name"] for item in response["required_inputs"]},
        )

    def test_installer_entrypoint_defaults_to_install(self) -> None:
        completed = subprocess.run(
            [
                str(INSTALLER),
                "--dry-run",
                "--json",
                "--non-interactive",
            ],
            cwd=PRODUCT_ROOT,
            env=clean_environment(),
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 64, completed.stderr)
        response = json.loads(completed.stdout)
        self.assertEqual(response["operation"], "install")
        self.assertEqual(response["phase"], "plan")
        self.assertEqual(response["status"], "blocked")

    @unittest.skipIf(os.geteuid() == 0, "root does not use the sudo handoff")
    def test_installer_forwards_configuration_through_sudo(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            capture = root / "arguments"
            sudo = root / "sudo"
            sudo.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$@\" >\"$TEST_CAPTURE\"\n",
                encoding="utf-8",
            )
            os.chmod(sudo, 0o755)
            installer = root / "install.sh"
            installer.write_text(
                INSTALLER.read_text(encoding="utf-8").replace(
                    "/usr/bin/sudo",
                    str(sudo),
                ),
                encoding="utf-8",
            )
            os.chmod(installer, 0o755)
            environment = clean_environment()
            environment.update(
                {
                    "TEST_CAPTURE": str(capture),
                    "BEEP_CHAT_PORT": "59001",
                    "BEEP_PROVIDER": "openai",
                }
            )
            completed = subprocess.run(
                [str(installer), "--yes", "--non-interactive"],
                cwd=PRODUCT_ROOT,
                env=environment,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            arguments = capture.read_text(encoding="utf-8").splitlines()
        self.assertIn("/usr/bin/env", arguments)
        self.assertIn("-i", arguments)
        self.assertIn("BEEP_CHAT_PORT=59001", arguments)
        self.assertIn("BEEP_PROVIDER=openai", arguments)
        self.assertIn(str(root / "manage.sh"), arguments)

    @unittest.skipIf(os.geteuid() == 0, "root does not use the sudo handoff")
    def test_installer_rejects_raw_secret_before_sudo(self) -> None:
        environment = clean_environment()
        environment["BEEP_API_KEY"] = "forbidden-inline-value"
        completed = subprocess.run(
            [str(INSTALLER), "--yes", "--non-interactive"],
            cwd=PRODUCT_ROOT,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 65)
        self.assertIn("Raw Beep secrets are prohibited", completed.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root does not use the sudo handoff")
    def test_installer_rejects_unknown_environment_before_sudo(self) -> None:
        environment = clean_environment()
        environment["BEEP_UNKNOWN_INPUT"] = "value"
        completed = subprocess.run(
            [str(INSTALLER), "--yes", "--non-interactive"],
            cwd=PRODUCT_ROOT,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 65)
        self.assertIn("Unknown Beep environment variable", completed.stderr)

    def test_kill_has_a_non_mutating_plan_surface(self) -> None:
        completed, response = self.run_manager("kill", "--dry-run")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(response["phase"], "plan")
        self.assertTrue(response["requires_confirmation"])
        self.assertTrue(any(step["id"] == "kill.execute" for step in response["steps"]))

    def test_raw_secret_environment_is_rejected_specifically(self) -> None:
        environment = clean_environment()
        environment["BEEP_API_KEY"] = "forbidden-inline-value"
        completed, response = self.run_manager(
            "describe",
            environment=environment,
        )
        self.assertEqual(completed.returncode, 65)
        self.assertEqual(response["errors"][0]["code"], "RAW_SECRET_REJECTED")


if __name__ == "__main__":
    unittest.main()
