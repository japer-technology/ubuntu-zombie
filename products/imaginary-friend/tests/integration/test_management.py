from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

PRODUCT_ROOT = Path(__file__).resolve().parents[2]
MANAGE = PRODUCT_ROOT / "scripts" / "manage.sh"
INSTALLER = PRODUCT_ROOT / "scripts" / "install.sh"


class ManagementTests(unittest.TestCase):
    def run_manage(
        self, *arguments: str, extra_environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update(extra_environment or {})
        return subprocess.run(
            [str(MANAGE), *arguments],
            cwd=PRODUCT_ROOT,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_describe_is_valid_and_non_mutating(self) -> None:
        completed = self.run_manage("describe", "--json")
        self.assertEqual(completed.returncode, 0, completed.stderr)
        value = json.loads(completed.stdout)
        self.assertEqual(value["product_id"], "imaginary-friend")
        self.assertEqual(value["phase"], "read")
        self.assertFalse(value["changed"])

    def test_installer_entrypoint_defaults_to_install(self) -> None:
        environment = dict(os.environ)
        environment["FRIEND_NONINTERACTIVE"] = "1"
        completed = subprocess.run(
            [str(INSTALLER), "--dry-run", "--json"],
            cwd=PRODUCT_ROOT,
            env=environment,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(completed.returncode, 64)
        value = json.loads(completed.stdout)
        self.assertEqual(value["operation"], "install")
        self.assertEqual(value["phase"], "plan")

    def test_unattended_missing_input_exits_64_with_json(self) -> None:
        completed = self.run_manage(
            "install",
            "--dry-run",
            "--json",
            extra_environment={"FRIEND_NONINTERACTIVE": "1"},
        )
        self.assertEqual(completed.returncode, 64)
        value = json.loads(completed.stdout)
        self.assertEqual(value["errors"][0]["code"], "MISSING_INPUT")
        self.assertEqual(value["phase"], "plan")

    def test_product_entrypoints_work_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            standalone = Path(directory) / "imaginary-friend"
            shutil.copytree(
                PRODUCT_ROOT,
                standalone,
                ignore=shutil.ignore_patterns("dist", "__pycache__", "*.pyc", "tests"),
            )
            environment = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("FRIEND_", "IMAGINARY_FRIEND_"))
                and key != "PYTHONPATH"
            }
            for entrypoint, arguments, expected in (
                ("manage.sh", ["describe", "--json"], 0),
                ("install.sh", ["--help"], 0),
                ("install.sh", ["--dry-run", "--non-interactive", "--json"], 64),
            ):
                with self.subTest(entrypoint=entrypoint, arguments=arguments):
                    completed = subprocess.run(
                        [str(standalone / "scripts" / entrypoint), *arguments],
                        cwd=directory,
                        env=environment,
                        check=False,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=30,
                    )
                    self.assertEqual(completed.returncode, expected, completed.stderr)
                    if "--json" in arguments:
                        value = json.loads(completed.stdout)
                        self.assertEqual(value["product_id"], "imaginary-friend")
                        self.assertFalse(value["changed"])
                    else:
                        self.assertIn("Imaginary Friend", completed.stdout)

    def test_unknown_friend_environment_fails_closed(self) -> None:
        completed = self.run_manage(
            "describe",
            "--json",
            extra_environment={"FRIEND_RAW_PASSWORD": "not-a-secret"},
        )
        self.assertEqual(completed.returncode, 65)
        value = json.loads(completed.stdout)
        self.assertEqual(value["errors"][0]["code"], "UNKNOWN_INPUT")

    def test_dry_run_does_not_create_lifecycle_lock(self) -> None:
        lock = Path("/run/lock/imaginary-friend.lock")
        existed = lock.exists()
        self.run_manage(
            "install",
            "--dry-run",
            "--json",
            extra_environment={"FRIEND_NONINTERACTIVE": "1"},
        )
        self.assertEqual(lock.exists(), existed)


if __name__ == "__main__":
    unittest.main()
